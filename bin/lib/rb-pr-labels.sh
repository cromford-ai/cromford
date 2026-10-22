#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/lib/rb/pr.sh inside bin/run-build.sh, whose gates stage has ALREADY armed the repo identity (gh_default_auth_for_project), and by bin/lib/pool-push-rejected.sh under the caller's GH_TOKEN; a second mint here would override that choice (same shape as bin/lib/rb-full-ci-label.sh).
# bin/lib/rb-pr-labels.sh — a ticket's `PR-Labels:` line labels its PR (BH-7929).
# Sourced by the `pr labels` block of bin/lib/rb/pr.sh and by
# ppr_reap_landed in bin/lib/pool-push-rejected.sh. Functions only.
#
# THE LINE. Key `PR-Labels:` or `PR-Label:`, any case, at the start of a line,
# after optional spaces, a `- ` or `* ` bullet and one backtick (the
# bin/lib/spec-repos.sh grammar). The key inside a sentence does not count, and
# neither does a line in a ``` or ~~~ fence. Values split on commas only (a
# GitHub label can hold spaces), each trimmed and optionally in backticks.
# Empty values, values over 50 chars or with a control char are dropped;
# duplicates are dropped; at most PRL_MAX are kept. Body only: a comment author
# must not change what a PR carries.
#
# THE WRITE. Each label is read first (GET repos/<slug>/labels/<name>). 200 is
# kept. 404 or an unread status is one pipeline.log line and the label is
# skipped: the issues-labels POST would CREATE a missing label. The kept labels
# go in ONE POST repos/<slug>/issues/<n>/labels, a separate REST write after the
# create (a `--label` flag fails the whole create on one unknown label). The
# POST is idempotent, so a rebuild or an adopted PR repeats it safely.

[ -n "${_PRL_LOADED:-}" ] && declare -F prl_apply >/dev/null && return 0
_PRL_LOADED=1
PRL_MAX=10

# prl_parse — ticket body on stdin, the declared labels on stdout, one a line.
prl_parse() {
  tr -d '\r' | awk -v max="$PRL_MAX" '
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
      if (substr(k, 1, 10) == "pr-labels:") v = substr(line, 11)
      else if (substr(k, 1, 9) == "pr-label:") v = substr(line, 10)
      else next
      n = split(v, w, /,/)
      for (i = 1; i <= n; i++) {
        l = w[i]
        gsub(/^[ \t]+|[ \t]+$/, "", l)
        sub(/^`/, "", l); sub(/`$/, "", l)
        gsub(/^[ \t]+|[ \t]+$/, "", l)
        if (l == "" || length(l) > 50 || l ~ /[[:cntrl:]]/) continue
        if (l in seen) continue
        seen[l] = 1
        if (c < max) { print l; c++ }
      }
    }'
}

# prl_apply <project> <pr-url> <ticket-meta.json> <pipeline-log> — always rc 0.
prl_apply() {
  local project="${1:-}" url="${2:-}" meta="${3:-}" log="${4:-/dev/null}"
  local body labels slug num l enc code ts kept=() args=()
  [ -n "$meta" ] && [ -r "$meta" ] || return 0
  body=$(jq -r '.body // ""' "$meta" 2>/dev/null) || return 0
  [ -n "$body" ] || return 0
  labels=$(printf '%s\n' "$body" | prl_parse)
  [ -n "$labels" ] || return 0
  ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  slug=$(sed -nE 's#^https://github.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p' <<<"$url")
  num=$(sed -nE 's#^https://github.com/[^/]+/[^/]+/pull/([0-9]+)$#\1#p' <<<"$url")
  if [ -z "$slug" ] || [ -z "$num" ]; then
    echo "$ts [$project] pr labels: '$url' is not a PR url — no labels" >> "$log"
    return 0
  fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    enc=$(jq -rn --arg l "$l" '$l|@uri' 2>/dev/null) || enc=""
    code=""
    [ -n "$enc" ] && code=$(gh api -i "repos/$slug/labels/$enc" 2>/dev/null | head -n 1 | tr -d '\r' \
      | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p')
    case "$code" in
      200) kept+=("$l"); args+=(-f "labels[]=$l") ;;
      404) echo "$ts [$project] pr labels: '$l' is not a label in $slug — skipped" >> "$log" ;;
      *)   echo "$ts [$project] pr labels: could not read label '$l' in $slug (HTTP ${code:-none}) — skipped" >> "$log" ;;
    esac
  done <<<"$labels"
  [ "${#kept[@]}" -gt 0 ] || return 0
  if gh api -X POST "repos/$slug/issues/$num/labels" "${args[@]}" >/dev/null 2>&1; then
    echo "$ts [$project] pr labels: labelled $url '$(IFS=,; printf '%s' "${kept[*]}" | sed 's/,/, /g')' from the ticket's PR-Labels line" >> "$log"
  else
    echo "$ts [$project] pr labels: could NOT label $url (POST repos/$slug/issues/$num/labels failed)" >> "$log"
  fi
  return 0
}

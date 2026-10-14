#!/bin/bash
# bin/lib/rb/cross-repo-read.sh — BH-5910: stop at PLAN when the plan needs a
# repo this build's GitHub tokens cannot read. Sourced by bin/lib/rb/plan.sh;
# defines functions only. Not a stage module (not in RB_MODULES).
#
# WHY. A pool token sees one repo. A plan that copies code from a sibling repo
# ran a whole execute stage, got "Repository not found" and ended with an empty
# diff. The planner now declares each repo it will read, one line each:
#
#   CROSS-REPO-READ: <owner>/<repo>
#
# and the gate probes each declared repo before execute. Only those lines count:
# plans name other repos in prose all the time, and a path like bin/lib looks
# like a slug.
#
#   xrepo_plan_note                  the PLAN prompt sentence, plus the repos
#                                    GH_EXTRA_READ_REPOS says this build reads
#   xrepo_declared <plan.md> [own]   the declared slugs, one per line: the own
#                                    slug dropped, deduped, at most 10
#   xrepo_probe <owner/repo>         ok | missing | unknown <why>
#   xrepo_gate <plan.md> <own> [log] rc 0 go on; rc 4 + the first missing slug
#                                    on stdout. One log line per unknown.
#
# THE PROBE. GET /repos/<repo> with each token this build holds: the read-only
# token (/run/harness-env/gh-token-read, else GH_EXTRA_READ_TOKEN), the live
# project token (gh_token_live, when sourced), then GH_TOKEN. Any 200 is ok.
# A 404 on EVERY token is missing. Anything else (401, 403, 429, 5xx, a timeout,
# no token at all) is unknown, and an unknown never blocks: a gate that parks
# builds on GitHub weather is worse than the empty diff it replaces.
# No token value is printed or logged.

XREPO_MAX=10

xrepo_plan_note() {
  printf '%s ' "CROSS-REPO READS: if this plan copies or reads code from any GitHub repo other than this project's own, write one line per repo, exactly \`CROSS-REPO-READ: <owner>/<repo>\`, at the start of the line; the build checks that it can read each one before execute."
  # BH-6576: on a pool machine with a read-only token, name what it reads and
  # how. Unset (every other build): the note above is the whole note.
  [ -n "${GH_EXTRA_READ_REPOS:-}" ] && printf '%s ' "This build can READ these repos (read-only): ${GH_EXTRA_READ_REPOS}. Read them with git (git clone --depth 1 https://github.com/<repo> /tmp/<name>); gh and the GitHub API use the project token and cannot read them."
  return 0
}

xrepo_declared() {
  local plan="$1" own="${2:-}"
  [ -s "$plan" ] || return 0
  sed -nE 's/^[[:space:]]*([-*][[:space:]]*)?`?CROSS-REPO-READ:[[:space:]]*([A-Za-z0-9-]+\/[A-Za-z0-9._-]+)`?[[:space:]]*$/\2/p' "$plan" \
    | awk -v own="$own" '{ k = tolower($0) } k != tolower(own) && !seen[k]++' \
    | head -n "$XREPO_MAX"
}

# _xrepo_tokens -> the tokens to try, one per line, deduped, never printed elsewhere.
_xrepo_tokens() {
  local rf="${GH_TOKEN_READ_FILE:-/run/harness-env/gh-token-read}" t live=""
  {
    [ -s "$rf" ] && tr -d ' \t\r\n' < "$rf" 2>/dev/null && echo
    printf '%s\n' "${GH_EXTRA_READ_TOKEN:-}"
    if command -v gh_token_live >/dev/null 2>&1; then
      live=$(gh_token_live >/dev/null 2>&1 && printf '%s' "${GH_TOKEN:-}") || live=""
      # gh_token_live exports GH_TOKEN; the subshell above keeps this shell's.
      printf '%s\n' "$live"
    fi
    printf '%s\n' "${GH_TOKEN:-}"
  } | while IFS= read -r t; do [ -n "$t" ] && printf '%s\n' "$t"; done | awk '!seen[$0]++'
}

xrepo_probe() {
  local slug="$1" base="${GH_APP_API_BASE:-https://api.github.com}" t code n=0 n404=0 other=""
  while IFS= read -r t; do
    n=$((n + 1))
    code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: token $t" \
             -H "Accept: application/vnd.github+json" "$base/repos/$slug" 2>/dev/null) || true
    case "$code" in
      200) echo ok; return 0 ;;
      404) n404=$((n404 + 1)) ;;
      *)   other="$other ${code:-000}" ;;
    esac
  done < <(_xrepo_tokens)
  if [ "$n" = 0 ]; then echo "unknown no-token"; return 0; fi
  if [ "$n404" = "$n" ]; then echo missing; return 0; fi
  other="${other# }"
  echo "unknown http=${other// /,}"
}

xrepo_gate() {
  local plan="$1" own="${2:-}" log="${3:-/dev/null}" slug ans
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    ans=$(xrepo_probe "$slug")
    case "$ans" in
      ok) ;;
      missing) printf '%s\n' "$slug"; return 4 ;;
      *) echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') cross-repo-read $slug: $ans — could not check, not blocking" >> "$log" 2>/dev/null ;;
    esac
  done < <(xrepo_declared "$plan" "$own")
  return 0
}

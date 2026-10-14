#!/bin/bash
# bin/lib/token-redact.sh — scrub GitHub-token-shaped strings out of text
# before it lands in a build file a reader or a model sees (BH-6672).
# Sourced, never executed. Defines functions and does nothing else.
#
#   token_redact             stdin -> stdout filter
#   token_redact_file <path> the same, in place
#
# WHAT IS A TOKEN SHAPE. Each becomes `<redacted:github-token>`:
#   gh[pousr]_ + 30 or more alphanumerics   classic token, 36 after the prefix
#   gh[pousr]_ + digits + _ + 20 or more [A-Za-z0-9._-]
#                                           the newer installation token, an id
#                                           and a JWT (seen on a pool box,
#                                           2026-10-14)
#   github_pat_ + 22 or more [A-Za-z0-9_]   fine-grained PAT
#   x-access-token:<anything>@              the credential in a clone URL
# NOT a token shape: an identifier with an underscore after letters
# (ghs_fixture_installation_token, gh_app_only_for), a bare prefix, and a run
# under the floor. sed -E only, no awk interval: mawk lacks it.
#
# token_redact_file <path>
#   rc 0  scrubbed in place, or the path does not exist (nothing is created)
#   rc 1  the path is not a regular file (nothing is written), or the scrub
#         could not run: then the file holds ONE line, `HARNESS_REDACT: failed
#         — output withheld (token scrub could not run)`. Fail closed: a file
#         that could not be scrubbed is never kept as written.

token_redact() {
  sed -E \
    -e 's/gh[pousr]_[0-9]+_[A-Za-z0-9._-]{20,}/<redacted:github-token>/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{30,}/<redacted:github-token>/g' \
    -e 's/github_pat_[A-Za-z0-9_]{22,}/<redacted:github-token>/g' \
    -e 's/x-access-token:[^@[:space:]]+@/x-access-token:<redacted:github-token>@/g'
}

token_redact_file() {
  local f="${1:-}" tmp
  [ -n "$f" ] || return 1
  [ -e "$f" ] || [ -L "$f" ] || return 0
  [ -f "$f" ] || return 1
  tmp="$f.redact.$$"
  if token_redact < "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  printf '%s\n' 'HARNESS_REDACT: failed — output withheld (token scrub could not run)' > "$f"
  return 1
}

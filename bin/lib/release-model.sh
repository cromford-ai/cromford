#!/bin/bash
# bin/lib/release-model.sh — BH-9862: where does a merge to the default branch
# deploy? Sourced, never run.
#
# THE FACT. Most projects deploy `main` to production. A project with a row in
# catalog/release-model.tsv deploys `main` to a STAGING site, and production
# moves only when a person runs that project's release. For such a project a
# merge is "On staging", never "live", and nothing in the harness may act on
# production because a merge happened.
#
# THE DEFAULT IS TODAY. No file, no row, an unreadable file, a row with a
# model this lib does not know, or a staging row with no base: every one of
# those answers `production`, so every other project runs byte for byte as it
# did before this file existed.
#
#   release_model <project>              staging | production
#   release_is_staging <project>         rc 0 when the model is staging
#   release_staging_base <project>       the staging site, or nothing
#   release_staging_version_url <project> its version address, or nothing
#   release_model_apply <project>        for a staging project, point the
#                                        post-merge reads at staging:
#                                          RELEASE_MODEL=staging
#                                          RELEASE_STAGING_BASE=<base>
#                                          VERSION_URL=<version_url>
#                                          DEPLOY_ROLLBACK=off
#                                          VERSION_AUTH, DEPLOY_HOOK_URL unset
#                                        Call it BELOW the env load, because the
#                                        project env file sets VERSION_URL to
#                                        production. For any other project it
#                                        changes nothing.
#
# WHY ROLLBACK IS OFF. The automatic revert exists to get a broken deploy out
# of production. A staging site that does not serve the newest merge is a page,
# and a revert PR on `main` would undo work that never reached a client.
#
# WHY VERSION_AUTH IS UNSET. It carries the production internal token, and a
# production secret is not sent to a second site.
#
# WHY DEPLOY_HOOK_URL IS UNSET. Staging deploys on the push itself. A hook kept
# from before the split builds whatever branch it was made for.

_release_model_file() {
  # BH-2613: no literal root here. With no root the "$h/..." candidate is
  # empty and is skipped, so no path is ever built from an empty root.
  local h="${HARNESS:-${H:-}}" f
  for f in "${RELEASE_MODEL_FILE:-}" "${h:+$h/catalog/release-model.tsv}" \
           "$(dirname "${BASH_SOURCE[0]}")/../../catalog/release-model.tsv"; do
    [ -n "$f" ] && [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# _release_model_field <project> <column 2..4> -> that column, or rc 1 with no
# row. awk splits on the TAB itself, so an EMPTY column stays empty; a shell
# `read` would fold two tabs into one and shift the next column left.
_release_model_field() {
  local p="${1:-}" n="${2:-}" f
  [ -n "$p" ] || return 1
  f=$(_release_model_file) || return 1
  awk -F'\t' -v p="$p" -v n="$n" '
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == p { print $n; found = 1; exit }
    END { exit found ? 0 : 1 }' "$f" 2>/dev/null
}

release_model() {
  local model base
  model=$(_release_model_field "${1:-}" 2) || { echo production; return 0; }
  base=$(_release_model_field "$1" 3)
  case "$model" in
    staging) case "$base" in https://?*) echo staging; return 0 ;; esac ;;
  esac
  echo production
}

release_is_staging() { [ "$(release_model "${1:-}")" = staging ]; }

release_staging_base() {
  local base
  release_is_staging "${1:-}" || return 0
  base=$(_release_model_field "$1" 3)
  printf '%s\n' "${base%/}"
}

release_staging_version_url() {
  local base ver
  release_is_staging "${1:-}" || return 0
  base=$(_release_model_field "$1" 3); ver=$(_release_model_field "$1" 4)
  case "$ver" in https://?*) ;; *) ver="${base%/}/api/internal/version" ;; esac
  printf '%s\n' "$ver"
}

release_model_apply() {
  release_is_staging "${1:-}" || return 0
  RELEASE_MODEL=staging
  RELEASE_STAGING_BASE=$(release_staging_base "$1")
  VERSION_URL=$(release_staging_version_url "$1")
  DEPLOY_ROLLBACK=off
  unset VERSION_AUTH DEPLOY_HOOK_URL
  export RELEASE_MODEL RELEASE_STAGING_BASE VERSION_URL DEPLOY_ROLLBACK
}

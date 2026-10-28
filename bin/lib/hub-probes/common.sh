#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/common.sh — BH-3447 (BH-3434.0): the hub-probe allowlists,
# the full argument validator and the fixed-case dispatcher. Sourced, never run.
#
# hp_validate <probe> [args...]
#   rc 0 when the probe name is one of HP_PROBES or HP_SCREEN_PROBES and its
#   args are exactly the count and shape that probe takes; rc 2 otherwise.
#   Prints nothing.
#     app-status-write <owner/repo> <40-hex sha>  (neither half may be . or ..)
#     app-permissions <app-slug>
#     app-installation-repos
#     d1-count <table in HP_D1_TABLES> <template in HP_D1_TEMPLATES>
#     tracker-test <linear|jira|board> <lower-case envelope uuid> (HP_SCREEN_PROBES)
#     repo-detect <owner/repo>  (neither half . or ..)        (HP_SCREEN_PROBES)
#     ready-facts <project>     ([a-z0-9][a-z0-9-]{0,18})     (HP_SCREEN_PROBES)
#     repo-create <owner> <name> <template in HP_TEMPLATE_KEYS> (HP_SCREEN_PROBES)
# hp_run <probe> [args...]
#   Validates first: a reject is rc 2 and nothing else runs. Then a fixed case
#   maps the name to bin/lib/hub-probes/<probe>.sh and hp_probe_<probe_name>,
#   sources that file only if it exists, and calls the function. No function →
#   prints `not-implemented`, rc 1. Nothing from the input is run as code, and no path or function name is
#   ever built from the input.
#
# The probe contract (each <probe>.sh): print the output lines on stdout, set
# HP_HTTP_STATUS, return 0 for PASS and anything else for FAIL. hp_run returns
# the probe's 0 as 0 and anything else as 1, so a probe can never answer 2 and
# read as a validation reject.
#
# The allowlists are code constants on purpose: they bound what a board comment
# may make the hub read, so a settings row must not be able to widen them.
HP_PROBES="app-status-write app-permissions app-installation-repos d1-count"
# HP_SCREEN_PROBES are filed by a worker route for a console screen, never by a
# board comment: tracker-test is filed by POST /api/onboarding/tracker-test
# (worker/jobs/src/routes/onboarding-tracker.js). hp_validate accepts them too.
# BH-7997 (BH-7935): repo-detect, ready-facts and repo-create are filed by the
# onboarding routes (worker/jobs/src/routes/onboarding-repo.js and siblings).
# request.sh files HP_PROBES only, so a build's HUB_PROBE: line cannot file them.
HP_SCREEN_PROBES="tracker-test repo-detect ready-facts repo-create"
HP_TRACKER_KINDS="linear jira board"
HP_TEMPLATE_KEYS="nextjs worker empty"
HP_D1_TABLES="jobs ledgers split_watchdog_actions hub_probe_requests"
HP_D1_TEMPLATES="all last-24h"

# _hp_in <word> <list> — whole-word membership; a word with whitespace or an empty word never matches.
_hp_in() {
  [ -n "$1" ] || return 1
  case "$1" in *[[:space:]]*) return 1 ;; esac
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

hp_validate() {
  [ $# -ge 1 ] || return 2
  local re_repo='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' re_sha='^[0-9a-f]{40}$' re_slug='^[a-z0-9][a-z0-9-]{0,62}$'
  case "$1" in
    app-status-write)
      [ $# -eq 3 ] && [[ "$2" =~ $re_repo ]] && [[ "$3" =~ $re_sha ]] || return 2
      # The repo lands in a REST path, so a dot segment would walk out of repos/.
      case "/$2/" in */./*|*/../*) return 2 ;; esac ;;
    app-permissions)
      [ $# -eq 2 ] && [[ "$2" =~ $re_slug ]] || return 2 ;;
    app-installation-repos)
      [ $# -eq 1 ] || return 2 ;;
    d1-count)
      [ $# -eq 3 ] && _hp_in "$2" "$HP_D1_TABLES" && _hp_in "$3" "$HP_D1_TEMPLATES" || return 2 ;;
    tracker-test)
      [ $# -eq 3 ] && _hp_in "$2" "$HP_TRACKER_KINDS" \
        && [[ "$3" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 2 ;;
    repo-detect)
      [ $# -eq 2 ] && [[ "$2" =~ $re_repo ]] || return 2
      case "/$2/" in */./*|*/../*) return 2 ;; esac ;;
    ready-facts)
      [ $# -eq 2 ] && [[ "$2" =~ ^[a-z0-9][a-z0-9-]{0,18}$ ]] || return 2 ;;
    repo-create)
      [ $# -eq 4 ] && [[ "$2" =~ ^[A-Za-z0-9-]{1,39}$ ]] && [[ "$3" =~ ^[A-Za-z0-9_.-]{1,100}$ ]] \
        && _hp_in "$4" "$HP_TEMPLATE_KEYS" || return 2
      case "$3" in .|..) return 2 ;; esac ;;
    *) return 2 ;;
  esac
  return 0
}

hp_run() {
  hp_validate "$@" || return 2
  local dir stem fn
  dir=$(dirname "${BASH_SOURCE[0]}")
  case "$1" in
    app-status-write)       stem=app-status-write;       fn=hp_probe_app_status_write ;;
    app-permissions)        stem=app-permissions;        fn=hp_probe_app_permissions ;;
    app-installation-repos) stem=app-installation-repos; fn=hp_probe_app_installation_repos ;;
    d1-count)               stem=d1-count;               fn=hp_probe_d1_count ;;
    tracker-test)           stem=tracker-test;           fn=hp_probe_tracker_test ;;
    repo-detect)            stem=repo-detect;            fn=hp_probe_repo_detect ;;
    ready-facts)            stem=ready-facts;            fn=hp_probe_ready_facts ;;
    repo-create)            stem=repo-create;            fn=hp_probe_repo_create ;;
    *) return 2 ;;
  esac
  if [ -f "$dir/$stem.sh" ]; then
    # shellcheck source=/dev/null
    . "$dir/$stem.sh" || return 1
  fi
  HP_HTTP_STATUS=""
  if ! declare -F "$fn" >/dev/null; then
    echo "not-implemented"
    return 1
  fi
  "$fn" "${@:2}" && return 0
  return 1
}

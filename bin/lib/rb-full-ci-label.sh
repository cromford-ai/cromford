#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/lib/rb/pr.sh inside bin/run-build.sh, whose gates stage has ALREADY armed the repo identity (gh_default_auth_for_project); a second mint here would override that choice (same shape as the hotfix label POST above the block).
# bin/lib/rb-full-ci-label.sh — the full-CI label at PR open (BH-7241).
# Sourced by the `full-ci label` block of bin/lib/rb/pr.sh. Functions only.
#
# project-6's CI reads a `full-ci` label to run its full lane. Without it a
# harness PR waited about 11 min for a person to add it. fcl_apply runs the
# target repo's own lane classifier on the PR's worktree and adds the label
# unless the classifier says `frontend`. A missing, failed or slow classifier
# adds it: the full lane is the safe side (project-6's own rule for an
# unreadable label). The label write is a separate REST POST, like the hotfix
# label above the block, and a failed write never fails the build.

# fcl_apply <project> <pr-url> <worktree> <base-branch> <pipeline-log> — always rc 0.
#   Knobs (lib_env_apply rb-full-ci-label <project>): FULL_CI_LABEL (empty =
#   off), FULL_CI_LANE_SCRIPT (scripts/ci/lane.mjs), FULL_CI_LANE_TIMEOUT_S (60).
fcl_apply() {
  local project="${1:-}" url="${2:-}" wt="${3:-}" base="${4:-}" log="${5:-/dev/null}"
  local root label script to slug num mb out rc lane why
  root="${HARNESS:-${H:-}}"
  if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    # shellcheck source=bin/lib/lane-gate.sh
    . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1 || true
  fi
  # A subshell, so one project's row never leaks into the next call's env.
  IFS=$'\x1f' read -r label script to <<<"$( { command -v lib_env_apply >/dev/null 2>&1 \
      && lib_env_apply rb-full-ci-label "$project" >/dev/null 2>&1; } || true
    printf '%s\x1f%s\x1f%s' "${FULL_CI_LABEL:-}" "${FULL_CI_LANE_SCRIPT:-}" "${FULL_CI_LANE_TIMEOUT_S:-}" )"
  [ -n "$label" ] || return 0
  [ -n "$script" ] || script=scripts/ci/lane.mjs
  case "$to" in ''|*[!0-9]*|0) to=60 ;; esac
  slug=$(sed -nE 's#^https://github.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p' <<<"$url")
  num=$(sed -nE 's#^https://github.com/[^/]+/[^/]+/pull/([0-9]+)$#\1#p' <<<"$url")
  if [ -z "$slug" ] || [ -z "$num" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$project] full-ci label: '$url' is not a PR url — no label" >> "$log"
    return 0
  fi
  lane=""
  if [ -z "$wt" ] || [ ! -f "$wt/$script" ]; then
    why="lane script missing: full lane is the safe side"
  elif ! command -v node >/dev/null 2>&1; then
    why="no node on this box: full lane is the safe side"
  else
    mb=$(git -C "$wt" merge-base "origin/$base" HEAD 2>/dev/null) || mb=""
    out=$(mktemp "${TMPDIR:-/tmp}/fcl-out.XXXXXX") || out=""
    rc=0
    ( cd "$wt" && timeout -k 5 "$to" node "$script" --base "${mb:-origin/$base}" --head HEAD \
        --github-output "${out:-/dev/null}" --summary /dev/null ) >/dev/null 2>&1 || rc=$?
    [ -n "$out" ] && lane=$(sed -n 's/^lane=//p' "$out" 2>/dev/null | tail -1 | tr -d '[:space:]')
    [ -n "$out" ] && rm -f "$out"
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      lane=""; why="lane script ran past ${to}s: full lane is the safe side"
    elif [ "$rc" != 0 ]; then
      lane=""; why="lane script failed (rc $rc): full lane is the safe side"
    elif [ -z "$lane" ]; then
      why="lane script printed no lane= line: full lane is the safe side"
    else
      why="lane $lane"
    fi
  fi
  if [ "$lane" = frontend ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$project] full-ci label: lane frontend — no '$label' label on $url" >> "$log"
    return 0
  fi
  if gh api -X POST "repos/$slug/issues/$num/labels" -f "labels[]=$label" >/dev/null 2>&1; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$project] full-ci label: $why — labelled $url '$label'" >> "$log"
  else
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$project] full-ci label: $why — could NOT label $url '$label' (POST repos/$slug/issues/$num/labels failed); the PR runs the lane its CI picks without it" >> "$log"
  fi
  return 0
}

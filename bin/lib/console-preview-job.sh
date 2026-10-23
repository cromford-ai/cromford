#!/bin/bash
# shellcheck shell=bash
# bin/lib/console-preview-job.sh — the MACHINE side of a console preview pool
# row (BH-8030). Sourced, never executed: no `set -e`, no `exit`, nothing runs
# at source time. fly/builder-runner.sh run_console_preview_job is its one
# production caller.
#
# WHY. The hub ran at load 55-60, and the console preview lane
# (bin/console-preview-deploy.sh, cron 727) ran `npm ci` and `vite build` for
# each console PR head on it. Under the settings row
# lane_placement.console-preview-deploy = fly the hub queues ONE pool row per
# head instead, and a short-lived Fly pool machine runs the build and the Pages
# preview upload. PR selection, the state files, the preview binding check, QA
# and the PR comment stay on the hub.
#
# THE JOB (job.json, carried from the row meta by bin/lib/queue-row-job.sh):
#   {"key":"CP-<pr>-<head8>-<job>", ...,
#    "console_preview":{"kind":"console_preview","slug":"owner/repo","pr":<n>,
#      "head":"<40 hex>","alias":"<pages branch alias>","acct":"<account id>",
#      "project":"<pages project>","wrangler":"<x.y.z>"}}
#
# THE RESULT, line 1 one of (bin/result-prefix-ok.sh admits CPV_):
#   CPV_DEPLOYED <head>
#   CPV_HEAD_FAILED <why>          the head's own fault (npm ci, vite build, a
#                                  dist the lane or Pages refused)
#   CPV_BOX_FAILED <stage>: <why>  the machine's fault (job, repo, fetch, token,
#                                  build isolation, an upload box error)
# then PR:, HEAD:, ALIAS:, STRIPPED: (only when cpv_copy_dist removed a file)
# and TIMINGS: total=<s>. The pool reap closes the row `done` with line 1, and
# the hub lane reads that line.
#
# THE SAME UNPRIVILEGED BUILD AS THE HUB. cpv_build_deploy (bin/lib/console-
# preview.sh) is the hub's own body: the head's tree is built as
# CONSOLE_PREVIEW_BUILD_USER (default nobody) with `npm ci --ignore-scripts`, a
# clean env and its own PID namespace; the deploy tree holds only the built
# dist/ and origin/main's Functions; wrangler is pinned. The hub queues only a
# same-repo head, and this body refuses a job whose slug is not the repo's own.
# The Pages token is /run/harness-env/cloudflare.env, pushed by bin/fly-pool.sh
# for this row only (mode 0600, root); the runner removes it after the job.
#
# Root: ${HARNESS:-/data/harness}.

_CPVJ_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
declare -F cpv_build_deploy >/dev/null || . "$_CPVJ_LIB/console-preview.sh" || return 1

# _cpvj_field <job> <name> — one string field of .console_preview, or "".
_cpvj_field() { jq -r --arg f "$2" '(.console_preview // {})[$f] // "" | tostring' "$1" 2>/dev/null; }

# cpv_pool_job_run <repo> <job.json> <result-file> — rc 0 only on CPV_DEPLOYED.
cpv_pool_job_run() {
  local repo="${1:-}" job="${2:-}" out="${3:-}" slug pr head alias acct proj wr origin lo lsl t0 rc=0 why="" word stage
  local -
  set -uo pipefail
  t0=$(date -u +%s)
  slug=$(_cpvj_field "$job" slug); pr=$(_cpvj_field "$job" pr); head=$(_cpvj_field "$job" head)
  alias=$(_cpvj_field "$job" alias); acct=$(_cpvj_field "$job" acct); proj=$(_cpvj_field "$job" project)
  wr=$(_cpvj_field "$job" wrangler)
  CPV_B=""; CPV_D=""; CPV_STRIPPED=""
  stage=job
  if ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then why="slug '$slug' is not owner/repo"
  elif ! [[ "$pr" =~ ^[0-9]+$ ]]; then why="pr '$pr' is not a number"
  elif ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then why="head '$head' is not 40 hex"
  elif ! [[ "$alias" =~ ^[a-z0-9][a-z0-9-]{0,27}$ ]]; then why="alias '$alias' is not a Pages branch alias"
  elif ! [[ "$acct" =~ ^[0-9a-zA-Z-]{6,64}$ ]]; then why="acct is not an account id"
  elif ! [[ "$proj" =~ ^[a-z0-9][a-z0-9-]{0,57}$ ]]; then why="project '$proj' is not a Pages project name"
  elif ! [[ "$wr" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then why="wrangler '$wr' is not an exact version"
  fi
  if [ -z "$why" ]; then
    stage=repo
    origin=$(git -C "$repo" config --get remote.origin.url 2>/dev/null)
    origin=${origin%.git}; origin=${origin%/}
    if [ -z "$origin" ]; then why="no repo at $repo"
    else
      lo=$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]'); lsl=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
      case "$lo" in
        */"$lsl"|*:"$lsl") ;;
        *) why="the slug $slug of the job is not the repo of this machine ($origin)" ;;
      esac
    fi
  fi
  if [ -z "$why" ]; then
    stage=fetch
    # Explicit destinations: a --depth clone is single-branch, and a bare fetch
    # of main would land in FETCH_HEAD only (bin/lib/rebase-job.sh step 3).
    if ! git -C "$repo" fetch -q --no-write-fetch-head origin "+refs/heads/main:refs/remotes/origin/main" "refs/pull/$pr/head" >/dev/null 2>&1; then
      why="git fetch of main and refs/pull/$pr/head failed"
    elif ! git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null; then
      why="head ${head:0:12} is not refs/pull/$pr/head any more"
    fi
  fi
  if [ -z "$why" ]; then
    stage=token
    CPV_CFENV="${CPV_POOL_CFENV:-/run/harness-env/cloudflare.env}"
    CPV_TOKV=$( set -a; . "$CPV_CFENV" >/dev/null 2>&1; set +a; printf '%s' "${CLOUDFLARE_API_TOKEN:-}" )
    [ -n "$CPV_TOKV" ] || why="no CLOUDFLARE_API_TOKEN in $CPV_CFENV"
  fi
  if [ -n "$why" ]; then
    word="CPV_BOX_FAILED $stage: $why"
  else
    CPV_CO="$repo"; CPV_BT="${CONSOLE_PREVIEW_BUILD_TMP:-/tmp}"; CPV_SNAP_DIR="${CPV_POOL_SNAP_DIR:-${TMPDIR:-/tmp}}"
    CPV_ACCT="$acct"; CPV_WRANGLER="$wr"
    CONSOLE_PAGES_PROJECT="$proj" cpv_build_deploy "$pr" "$alias" "$head" "-" || rc=$?
    case "$rc" in
      0) word="CPV_DEPLOYED $head" ;;
      1) word="CPV_HEAD_FAILED ${CPV_HEAD_WHY:-the build of the head failed}" ;;
      *) word="CPV_BOX_FAILED ${BOX_STAGE:-build}: ${BOX_WHY:-no reason}" ;;
    esac
  fi
  case "$CPV_B" in */console-preview-build.?*) rm -rf -- "$CPV_B" ;; esac
  case "$CPV_D" in */console-preview-snap.?*) rm -rf -- "$CPV_D" ;; esac
  CPV_B=""; CPV_D=""; CPV_TOKV=""
  word=$(printf '%s' "$word" | tr '\n\t\r' '   ' | cut -c1-400)
  {
    printf '%s\nPR: %s\nHEAD: %s\nALIAS: %s\n' "$word" "${pr:--}" "${head:--}" "${alias:--}"
    [ -z "${CPV_STRIPPED:-}" ] || printf 'STRIPPED:%s\n' "$CPV_STRIPPED"
    printf 'TIMINGS: total=%s\n' "$(( $(date -u +%s) - t0 ))"
  } > "$out"
  [ "${word%% *}" = CPV_DEPLOYED ]
}

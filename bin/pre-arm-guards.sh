#!/bin/bash
# bin/pre-arm-guards.sh <owner/repo> <pr-number>
#   Dispatch the repo's "static-guards.yml" workflow for the PR (it merges the
#   PR head into CURRENT main inside the job and runs tests/static-guards.txt
#   plus every test that imports a module the PR changed), wait for it, and
#   answer:
#     rc 0  green — arm the merge
#     rc 1  RED   — stdout lists the failing test files, one per line; PARK.
#           Also a gated repo (PRE_ARM_PREVIEW_PROJECTS, default project-3) whose
#           PR head's newest Vercel preview is ERROR: stdout is the one line
#           `vercel-preview: Vercel preview ERROR on <head12> (<url>)`, and no
#           workflow is dispatched (bin/lib/pre-arm-preview.sh)
#     rc 2  could not check (no such workflow on that repo, gh/API failure,
#           a failure before any test ran) — the caller logs and decides;
#           fail-open by default since most fleet repos carry no suite
#     rc 3  NOT GREEN, retry — the run was cancelled (the workflow's
#           concurrency group superseded it with a newer dispatch), skipped,
#           TIMED OUT on the runner, is STILL RUNNING when our wait ends, or
#           was green against a main that has MOVED since (the run logs
#           `main=<sha>`; compared with origin/main at answer time);
#           nothing was proven either way, so the caller must not merge on it
#           and must not park on it: try again next tick. A run that outlives
#           the wait is never "could not check" — that read merged the exact
#           PRs whose importer set is largest (2026-09-12). Also a gated
#           repo whose head preview is still BUILDING, QUEUED or INITIALIZING
#           and younger than PRE_ARM_PREVIEW_WAIT_MIN minutes.
#
# Why: CI at a PR head is green against the main of THAT moment. The class of
# test that only fails when the repo changed underneath the PR — ratchets
# walking src/ or scripts/, literal guards, pinned lists — is exactly what a
# later merge can turn red (project-5 #374 met #377's ratchet: three red
# production builds, 2026-09-12). Since the importer step the run is 2–20 min
# on GitHub's runner (a hub module fans out to most of the suite; the job's
# own budget is 25 min), so the wait covers that plus queueing. No pool, no hub.
set -uo pipefail
SLUG="${1:?owner/repo}"; PR="${2:?pr number}"
WORKFLOW="${PRE_ARM_WORKFLOW:-static-guards.yml}"
WAIT_SECS="${PRE_ARM_WAIT_SECS:-1800}"
POLL_SECS="${PRE_ARM_POLL_SECS:-15}"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$(cd "$(dirname "$0")" && pwd)/lib/gh-app-auth.sh" ] && . "$(cd "$(dirname "$0")" && pwd)/lib/gh-app-auth.sh"

# No such workflow on this repo → nothing to check (rc 2, one line on stderr).
# #425: one repo for the whole run — arm before the first gh call, reset at the end.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
# BH-1585: the three reads below are REST through bin/lib/gh-rest.sh (the
# workflow, the dispatched run's id, its status). Without the lib nothing is
# checked (rc 2), which is the "could not check" answer the caller already has.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$(cd "$(dirname "$0")" && pwd)/lib/gh-rest.sh" ] && . "$(cd "$(dirname "$0")" && pwd)/lib/gh-rest.sh"

# >>> vercel preview gate (BH-6501; tests/pre-arm-preview.bh-6501-test.sh drives this block)
# A gated repo's head whose own newest Vercel preview is ERROR parks (rc 1); a
# preview still building retries (rc 3). Every other answer logs one stderr line
# (`off` logs nothing) and the workflow check below runs as before.
# shellcheck source=bin/lib/pre-arm-preview.sh
[ -r "$(cd "$(dirname "$0")" && pwd)/lib/pre-arm-preview.sh" ] && . "$(cd "$(dirname "$0")" && pwd)/lib/pre-arm-preview.sh"
if command -v pap_check >/dev/null 2>&1; then
  H="${HARNESS:-/root/harness}"
  pap_knobs
  if pap_enabled "$SLUG"; then
    PAP_HEAD=""; PAP_REF=""
    HR=$(pap_head "$SLUG" "$PR") || HR=""
    read -r PAP_HEAD PAP_REF <<<"$HR"
    IFS=$'\t' read -r PAP_W PAP_D <<<"$(pap_check "$SLUG" "${PAP_HEAD:-}" "${PAP_REF:-}")"
    case "$PAP_W" in
      red)  echo "vercel-preview: ${PAP_D}"
            echo "pre-arm preview: RED $SLUG#$PR — $PAP_D" >&2
            command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; exit 1 ;;
      wait) echo "pre-arm preview: WAIT $SLUG#$PR — $PAP_D — not green, retry" >&2
            command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; exit 3 ;;
      off)  ;;
      *)    [ "$PAP_D" = - ] && PAP_D=""
            echo "pre-arm preview: $PAP_W $SLUG#$PR${PAP_D:+ — $PAP_D}" >&2 ;;
    esac
  fi
fi
# <<< vercel preview gate
command -v gh_rest >/dev/null 2>&1 || { echo "bin/lib/gh-rest.sh is not readable — could not check $SLUG#$PR" >&2; exit 2; }
gh_rest GET "repos/$SLUG/actions/workflows/$WORKFLOW" >/dev/null 2>&1 || { echo "no $WORKFLOW on $SLUG" >&2; exit 2; }

SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run "$WORKFLOW" -R "$SLUG" --ref main -f "pr=$PR" >/dev/null 2>&1 || { echo "dispatch failed for $SLUG#$PR" >&2; exit 2; }

# The dispatch API returns before the run exists; find OUR run by time.
RUN=""
for _ in $(seq 1 12); do
  sleep 5
  RUNS=""; gh_rest_var RUNS GET "repos/$SLUG/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=10" 2>/dev/null || RUNS=""
  RUN=$(jq -r --arg since "$SINCE" '[.workflow_runs[]? | select(.created_at >= $since)] | sort_by(.created_at) | last | .id // empty' <<<"${RUNS:-null}" 2>/dev/null)
  [ -n "$RUN" ] && break
done
[ -n "$RUN" ] || { echo "run never appeared for $SLUG#$PR" >&2; exit 2; }

END=$((SECONDS + WAIT_SECS))
while [ "$SECONDS" -lt "$END" ]; do
  J=""; gh_rest_var J GET "repos/$SLUG/actions/runs/$RUN" 2>/dev/null || { sleep "$POLL_SECS"; continue; }
  STATUS=$(jq -r '.status // empty' <<<"$J"); CONC=$(jq -r '.conclusion // empty' <<<"$J")
  if [ "$STATUS" = "completed" ]; then
    case "$CONC" in
      success)
        # A green result is only good for the main it ran against. Five
        # dispatches in one minute (2026-09-12, 19:55Z) each checked a PR
        # against the SAME main, then the PRs merged in sequence — #432 met
        # #431's seam test on main and nobody had checked that pair. The run
        # logs `main=<sha>` in its merge step; if origin/main has moved since,
        # nothing is proven for THIS arm: retry (rc 3), never merge.
        RUN_MAIN=$(gh run view "$RUN" -R "$SLUG" --log 2>/dev/null | grep -oE 'main=[0-9a-f]{40}' | head -1 | cut -d= -f2)
        LIVE_MAIN=$(gh api "repos/$SLUG/branches/main" --jq .commit.sha 2>/dev/null)
        if [ -n "$RUN_MAIN" ] && [ -n "$LIVE_MAIN" ] && [ "$RUN_MAIN" != "$LIVE_MAIN" ]; then
          echo "run $RUN was green against main ${RUN_MAIN:0:8} but main is now ${LIVE_MAIN:0:8} — not proven for this arm, retry" >&2
          exit 3
        fi
        [ -z "$RUN_MAIN" ] && echo "run $RUN logged no main= sha (older workflow copy?) — green taken as-is" >&2
        exit 0 ;;
      timed_out) echo "run $RUN hit the workflow's own time budget — not green, retry" >&2; exit 3 ;;
      failure)
        # Name the guard files that failed; the vitest reporter prints
        # "FAIL  tests/…test.ts > …" and " ❯ tests/…test.ts (n tests | m failed)".
        FILES=$(gh run view "$RUN" -R "$SLUG" --log-failed 2>/dev/null \
          | grep -oE 'tests/[A-Za-z0-9_./-]+\.test\.ts' | sort -u)
        if [ -z "$FILES" ]; then
          # No guard file in the failure: the run died BEFORE the guards ran
          # (checkout, the freshness step, npm ci, prisma). That is the gate's
          # own trouble, not the PR's — "could not check", never a park. The
          # first real dispatch (2026-09-12) failed exactly so on a depth-1
          # clone and would have parked every PR on the box.
          echo "run $RUN: $CONC before the guards ran (no test file in the failure) — could not check" >&2
          exit 2
        fi
        printf '%s\n' "$FILES"
        echo "run $RUN: $CONC" >&2
        exit 1 ;;
      cancelled|skipped) echo "run $RUN ended $CONC — not green, retry" >&2; exit 3 ;;
      *) echo "run $RUN ended $CONC" >&2; exit 2 ;;
    esac
  fi
  sleep "$POLL_SECS"
done
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
echo "run $RUN not finished after ${WAIT_SECS}s — not green, retry" >&2
exit 3
